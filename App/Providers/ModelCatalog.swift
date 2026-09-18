import Foundation

/// 模型数据改由 omp 的目录驱动 (user 2026-09-18: 「一切有用的和可能有用的都从 omp 的 provider 中拿出来」, then 「只搬数据」):
/// `Resources/Models/catalog.json`, trimmed from omp's `packages/catalog/src/models.json` by `scripts/import-omp-catalog.py`.
/// Formora's providers keep their own hosts and protocols; what a model *is* — name, window, output limit, images, price,
/// reasoning, compat flags — comes from here. Read once, on first use.
enum ModelCatalog {
    struct Cost: Equatable, Hashable, Sendable {
        var input: Double
        var output: Double
        var cacheRead: Double?
        var cacheWrite: Double?
    }

    struct Thinking: Equatable, Sendable {
        var mode: String?
        var efforts: [String]
        var requiresEffort: Bool
        var supportsDisplay: Bool
    }

    /// omp's compat flags for a row: the api's defaults under the row's own differences.
    struct Compat: Sendable {
        fileprivate let values: [String: JSONValue]

        func bool(_ key: String) -> Bool? { if case .bool(let value) = values[key] { value } else { nil } }
        func string(_ key: String) -> String? { if case .string(let value) = values[key] { value } else { nil } }
        func int(_ key: String) -> Int? { if case .number(let value) = values[key] { Int(value) } else { nil } }
        func map(_ key: String) -> [String: String] {
            guard case .object(let object) = values[key] else { return [:] }
            return object.compactMapValues { if case .string(let value) = $0 { value } else { nil } }
        }
    }

    struct Model: Sendable {
        let source: String
        let id: String
        let name: String?
        let api: String
        let baseURL: String?
        let reasoning: Bool
        let images: Bool
        let contextWindow: Int?
        let maxOutput: Int?
        let thinking: Thinking?
        let compat: Compat
        fileprivate let costs: [(from: Date, cost: Cost)]

        /// The price in force on `date`: the latest effective rate on or before it (omp `cost.timeBased.effectiveRates`).
        func cost(at date: Date = .now) -> Cost? { costs.last { $0.from <= date }?.cost ?? costs.first?.cost }

        /// The row was recorded on the protocol a request speaks — its flags apply (1.0.21). Codex's backend is Responses,
        /// OpenRouter's rows are OpenAI-compatible.
        func matches(_ apiProtocol: APIProtocol) -> Bool {
            switch api {
            case "openai-codex-responses": apiProtocol == .openAIResponses
            case "openrouter": apiProtocol == .openAICompletions
            default: api == apiProtocol.rawValue
            }
        }
    }

    /// Formora's provider → the omp sources that describe its models, in lookup order.
    static func sources(for providerID: String) -> [String] {
        switch providerID {
        case ChatGPTAuth.providerID: ["openai-codex"]
        // Formora talks to MiniMax OpenAI-style: omp's `minimax-code` rows are that wire; `minimax` (Anthropic-style) fills the rest.
        case "minimax": ["minimax-code", "minimax"]
        case "openai", "anthropic", "google", "deepseek", "moonshot", "zai", "xai", "openrouter": [providerID]
        default: []
        }
    }

    /// The first-party sources a custom platform's bare model id is matched against (1.0.21).
    private static let firstParty = ["anthropic", "openai", "google", "deepseek", "moonshot", "zai", "xai", "minimax"]

    /// A built-in's rows: its sources in order, each in id order; a model two sources both list comes once.
    static func models(providerID: String) -> [Model] {
        var seen = Set<String>()
        return sources(for: providerID).flatMap { table.sources[$0]?.models ?? [] }.filter { seen.insert($0.id).inserted }
    }

    /// The row for a model. A built-in: its own sources, by exact id. A custom platform: the source served from the same
    /// host (Command Code), id compared without case; then the first-party sources by the bare id (`vendor/model` →
    /// `model`), without case.
    static func model(providerID: String, modelID: String, baseURL: String? = nil) -> Model? {
        let own = sources(for: providerID)
        if !own.isEmpty {
            for source in own { if let row = table.sources[source]?.byID[modelID] { return row } }
            return nil
        }
        let lowered = modelID.lowercased()
        if let host = baseURL.flatMap({ URL(string: $0.trimmingCharacters(in: .whitespaces))?.host?.lowercased() }),
           let source = table.sources.values.first(where: { $0.hosts.contains(host) }), let row = source.byLowercased[lowered] {
            return row
        }
        let bare = String(lowered.split(separator: "/").last ?? Substring(lowered))
        for name in firstParty { if let row = table.sources[name]?.byLowercased[bare] { return row } }
        return nil
    }

    /// Facts Formora measured that differ from omp's table, applied over it.
    fileprivate static func verified(_ id: String, _ values: inout [String: JSONValue]) {
        // 真实测试 2026-09-18：DeepSeek 接受空的 reasoning_content——补空值，思考不中途关，缓存不丢（omp 记的是 false）。
        if id.lowercased().contains("deepseek") { values["allowsSyntheticReasoningContentForToolCalls"] = .bool(true) }
    }

    // MARK: The file

    fileprivate struct Source {
        let hosts: Set<String>
        let models: [Model]
        let byID: [String: Model]
        let byLowercased: [String: Model]
    }

    private struct Table {
        var sources: [String: Source] = [:]
    }

    private static let table: Table = load()

    private static func load() -> Table {
        guard let folder = Bundle.main.url(forResource: "Models", withExtension: nil),
              let data = try? Data(contentsOf: folder.appendingPathComponent("catalog.json")),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return Table() }
        var table = Table()
        for (name, source) in file.sources {
            let models = source.models.map { row -> Model in
                var values = file.compatDefaults[row.api] ?? [:]
                for (key, value) in row.compat ?? [:] {
                    if case .null = value { values[key] = nil } else { values[key] = value }
                }
                verified(row.id, &values)
                let thinking = row.thinking.map {
                    Thinking(mode: $0.mode, efforts: $0.efforts ?? [], requiresEffort: $0.requiresEffort ?? false,
                             supportsDisplay: $0.supportsDisplay ?? false)
                }
                return Model(source: name, id: row.id, name: row.name, api: row.api, baseURL: row.baseUrl, reasoning: row.reasoning ?? false,
                             images: row.input?.contains("image") == true, contextWindow: row.contextWindow, maxOutput: row.maxTokens,
                             thinking: thinking, compat: Compat(values: values), costs: row.cost?.schedule ?? [])
            }
            table.sources[name] = Source(hosts: Set(source.hosts), models: models,
                                         byID: Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                                         byLowercased: Dictionary(models.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first }))
        }
        return table
    }

    private struct File: Decodable {
        let compatDefaults: [String: [String: JSONValue]]
        let sources: [String: SourceFile]
    }

    private struct SourceFile: Decodable {
        let hosts: [String]
        let models: [Row]
    }

    private struct Row: Decodable {
        let id: String
        let name: String?
        let api: String
        let baseUrl: String?
        let reasoning: Bool?
        let input: [String]?
        let contextWindow: Int?
        let maxTokens: Int?
        let cost: CostFile?
        let thinking: ThinkingFile?
        let compat: [String: JSONValue]?
    }

    private struct ThinkingFile: Decodable {
        let mode: String?
        let efforts: [String]?
        let requiresEffort: Bool?
        let supportsDisplay: Bool?
    }

    private struct CostFile: Decodable {
        struct Rate: Decodable {
            let effectiveFrom: Double?
            let input: Double
            let output: Double
            let cacheRead: Double?
            let cacheWrite: Double?
        }

        struct TimeBased: Decodable {
            let effectiveRates: [Rate]?
        }

        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?
        let timeBased: TimeBased?

        /// The base price from the beginning of time, then each effective rate from its day (ms since 1970), in order.
        var schedule: [(from: Date, cost: Cost)] {
            var list: [(from: Date, cost: Cost)] = [(.distantPast, Cost(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite))]
            for rate in timeBased?.effectiveRates ?? [] {
                list.append((Date(timeIntervalSince1970: (rate.effectiveFrom ?? 0) / 1000),
                             Cost(input: rate.input, output: rate.output, cacheRead: rate.cacheRead, cacheWrite: rate.cacheWrite)))
            }
            return list.sorted { $0.from < $1.from }
        }
    }
}
