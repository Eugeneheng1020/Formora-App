import Foundation

/// 推理强度按模型 (user 2026-09-18: 「推理强度能不能走 omp 一样的表」): omp's per-model thinking metadata, read from
/// `ModelCatalog` (`Resources/Models/catalog.json`). A row says whether the model reasons, which levels it really has (DeepSeek V4:
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

    // MARK: The row

    /// The row for a model (`ModelCatalog`'s lookup — a custom platform's by its host, then by the bare id), as the menu
    /// and the wire read it. `nil` = not in the table.
    static func profile(providerID: String, modelID: String, apiProtocol: APIProtocol, baseURL: String? = nil) -> Profile? {
        guard let row = ModelCatalog.model(providerID: providerID, modelID: modelID, baseURL: baseURL) else { return nil }
        return Profile(reasoning: row.reasoning, mode: row.thinking?.mode.flatMap(Profile.Mode.init(rawValue:)),
                       efforts: (row.thinking?.efforts ?? []).compactMap(ReasoningLevel.init(rawValue:)),
                       requiresEffort: row.thinking?.requiresEffort ?? false, supportsDisplay: row.thinking?.supportsDisplay ?? false,
                       matchesWire: row.matches(apiProtocol))
    }

    // MARK: The menu

    /// The levels a request to this model can carry, in the menu's order: 自动 always; 关闭 unless the model can't
    /// stop; then the row's own levels, or without a usable row the ones the protocol's encoder tells apart.
    static func levels(providerID: String, modelID: String, apiProtocol: APIProtocol, baseURL: String? = nil) -> [ReasoningLevel] {
        let profile = profile(providerID: providerID, modelID: modelID, apiProtocol: apiProtocol, baseURL: baseURL)
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
    static func options(providerID: String, modelID: String, apiProtocol: APIProtocol, baseURL: String? = nil,
                        rejected: Set<ReasoningLevel> = []) -> [Option] {
        options(for: levels(providerID: providerID, modelID: modelID, apiProtocol: apiProtocol, baseURL: baseURL).filter { !rejected.contains($0) })
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
