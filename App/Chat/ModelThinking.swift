import Foundation

/// 推理强度按模型 (user 2026-09-18: 「推理强度能不能走 omp 一样的表」): omp's per-model thinking metadata
/// (`packages/catalog/src/models.json`, trimmed to Formora's nine providers by `scripts/import-omp-thinking.py` into
/// `Resources/Models/thinking.json`). A row says whether the model reasons, which levels it really has (DeepSeek V4:
/// low / high / max — no medium; Gemini 3.1 Pro: low / high and never off) and how they go on the wire (Claude 4.6+:
/// adaptive + effort, not a token budget; Gemini 3: `thinkingLevel`, not a budget). The menu lists what the row has, a
/// stored level the model lacks lands on the nearest one below (omp `clampThinkingLevelForModel`), and without a row
/// the protocol's encoder offers only the levels it can tell apart.
enum ModelThinking {
    struct Profile: Equatable, Sendable {
        /// omp's transport for the level (`ThinkingControlMode`); `nil` = the model reasons but can't be steered.
        enum Mode: String, Sendable {
            case effort, budget
            case googleLevel = "google-level"
            case anthropicAdaptive = "anthropic-adaptive"
            case anthropicBudgetEffort = "anthropic-budget-effort"
        }

        var reasoning: Bool
        var mode: Mode?
        /// The model's own levels, least to most; never `auto` or `off`.
        var efforts: [ReasoningLevel] = []
        /// The endpoint rejects thinking turned off.
        var requiresEffort = false
        /// Adaptive thinking takes `display` (Opus 4.7+, Fable/Mythos 5 — without it no thinking comes back).
        var supportsDisplay = false
        /// The row was recorded on the protocol the request speaks: its `mode` applies. omp reaches Z.AI and MiniMax
        /// through their Anthropic-style endpoints while Formora speaks OpenAI-style to them — then only the facts
        /// (`reasoning`, `requiresEffort`) carry over.
        var matchesWire = true
    }

    /// One line of the menu.
    struct Option: Equatable, Sendable {
        let level: ReasoningLevel
        let label: String
        let note: String
    }

    // MARK: The table

    private struct Row: Decodable {
        var api: String
        var reasoning: Bool
        var mode: String?
        var efforts: [String]?
        var requiresEffort: Bool?
        var supportsDisplay: Bool?
    }

    /// provider → model id → row, read once from the bundle.
    private static let table: [String: [String: Row]] = {
        guard let folder = Bundle.main.url(forResource: "Models", withExtension: nil),
              let data = try? Data(contentsOf: folder.appendingPathComponent("thinking.json")),
              let rows = try? JSONDecoder().decode([String: [String: Row]].self, from: data) else { return [:] }
        return rows
    }()

    /// The first-party providers a custom platform's model is matched against, by its bare id; the order settles a
    /// model two vendors list under one id.
    private static let firstParty = ["anthropic", "openai", "google", "deepseek", "moonshot", "zai", "xai", "minimax"]

    /// The row for a model — a built-in provider's by its id (the ChatGPT plan serves OpenAI's), a custom platform's
    /// by the bare model id among the first-party rows, spelling aside (Command Code: `moonshotai/Kimi-K3` is
    /// omp's `kimi-k3`). `nil` = not in the table.
    static func profile(providerID: String, modelID: String, apiProtocol: APIProtocol) -> Profile? {
        let provider = providerID == ChatGPTAuth.providerID ? "openai" : providerID
        if let rows = table[provider] {
            guard let row = rows[modelID] else { return nil }
            return profile(row, apiProtocol: apiProtocol)
        }
        let bare = (modelID.split(separator: "/").last.map(String.init) ?? modelID).lowercased()
        for vendor in firstParty {
            if let row = lowercased[vendor]?[bare] { return profile(row, apiProtocol: apiProtocol) }
        }
        return nil
    }

    /// The first-party rows by lowercased id, for a custom platform's spelling.
    private static let lowercased: [String: [String: Row]] = {
        var index: [String: [String: Row]] = [:]
        for vendor in firstParty {
            for (id, row) in table[vendor] ?? [:] where index[vendor]?[id.lowercased()] == nil {
                index[vendor, default: [:]][id.lowercased()] = row
            }
        }
        return index
    }()

    private static func profile(_ row: Row, apiProtocol: APIProtocol) -> Profile {
        let wire = row.api == apiProtocol.rawValue || (row.api == "openrouter" && apiProtocol == .openAICompletions)
        return Profile(reasoning: row.reasoning, mode: row.mode.flatMap(Profile.Mode.init(rawValue:)),
                       efforts: (row.efforts ?? []).compactMap(ReasoningLevel.init(rawValue:)),
                       requiresEffort: row.requiresEffort ?? false, supportsDisplay: row.supportsDisplay ?? false, matchesWire: wire)
    }

    // MARK: The menu

    /// The levels a request to this model can carry, in the menu's order: 自动 always; 关闭 unless the model can't
    /// stop; then the row's own levels, or without a usable row the ones the protocol's encoder tells apart.
    static func levels(providerID: String, modelID: String, apiProtocol: APIProtocol) -> [ReasoningLevel] {
        let profile = profile(providerID: providerID, modelID: modelID, apiProtocol: apiProtocol)
        if let profile {
            guard profile.reasoning else { return [.auto] }
            if profile.matchesWire {
                guard profile.mode != nil, !profile.efforts.isEmpty else { return [.auto] }
                return [.auto] + (profile.requiresEffort ? [] : [.off]) + ReasoningLevel.allCases.filter { profile.efforts.contains($0) }
            }
        }
        let dialect = ReasoningDialect.of(providerID: providerID, apiProtocol: apiProtocol)
        let fallback = encoderLevels(dialect)
        return profile?.requiresEffort == true ? fallback.filter { $0 != .off } : fallback
    }

    /// Without a row: the levels the encoder sends differently — two labels for one request would be a lie.
    static func encoderLevels(_ dialect: ReasoningDialect) -> [ReasoningLevel] {
        switch dialect {
        case .anthropic: [.auto, .off, .minimal, .low, .medium, .high, .xhigh]
        case .google: ReasoningLevel.allCases
        case .responses: [.auto, .off, .minimal, .low, .medium, .high, .xhigh]
        case .deepSeek: [.auto, .off, .low, .medium, .high]
        case .qwen, .zai: [.auto, .off, .high]
        case .openRouter, .openAIEffort: [.auto, .off, .minimal, .low, .medium, .high]
        }
    }

    /// The menu's lines for a model, the levels the host refused left out. A host with only a switch (Qwen, Z.AI,
    /// Moonshot) has one level besides 自动 and 关闭: it reads 开启.
    static func options(providerID: String, modelID: String, apiProtocol: APIProtocol, rejected: Set<ReasoningLevel> = []) -> [Option] {
        options(for: levels(providerID: providerID, modelID: modelID, apiProtocol: apiProtocol).filter { !rejected.contains($0) })
    }

    static func options(for levels: [ReasoningLevel]) -> [Option] {
        let steps = levels.filter { $0 != .auto && $0 != .off }
        return levels.map { level in
            if steps.count == 1, level == steps[0] { return Option(level: level, label: "开启", note: "开启推理，深浅由模型定") }
            return Option(level: level, label: level.label, note: level.note)
        }
    }

    /// Several models' levels as one menu (a group's members): every level any of them has, in the menu's order.
    static func union(_ lists: [[ReasoningLevel]]) -> [ReasoningLevel] {
        let all = Set(lists.joined()).union([.auto])
        return ReasoningLevel.allCases.filter { all.contains($0) }
    }

    /// The level a request carries: the level itself when the model has it; else the nearest below; else the lowest
    /// the model has; 自动 when there is nothing else. 关闭 on a model that can't stop thinks the least it can.
    static func clamp(_ level: ReasoningLevel, to levels: [ReasoningLevel]) -> ReasoningLevel {
        if levels.contains(level) { return level }
        let steps = ReasoningLevel.allCases.filter { $0 != .auto && $0 != .off && levels.contains($0) }
        guard let lowest = steps.first else { return .auto }
        if level == .off { return lowest }
        let order = ReasoningLevel.allCases
        let wanted = order.firstIndex(of: level) ?? 0
        return steps.last { order.firstIndex(of: $0)! < wanted } ?? lowest
    }
}
