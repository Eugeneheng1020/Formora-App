import Foundation

/// The 模型与权限 tab's unsaved model settings (explicit save, design spec §8.5–8.6), also used by
/// creation step 2 for the primary model.
struct AgentModelDraft: Equatable, Sendable {
    enum Source: String, Sendable {
        /// 「全部模型」: picked from the provider's real list.
        case list
        /// 「自定义 Model ID」.
        case custom
    }

    var providerID: String?
    var source: Source
    var modelID: String
    /// Per-phase model overrides (user 2026-09-16), each set or absent. There is no fallback model any more (user
    /// 2026-09-19: 舍弃备用模型) — a phase model falls back to the primary, the primary to nothing.
    var phase: [ModelPhase: ModelReference]

    init(providerID: String? = nil, source: Source = .list, modelID: String = "", phase: [ModelPhase: ModelReference] = [:]) {
        self.providerID = providerID
        self.source = source
        self.modelID = modelID
        self.phase = phase
    }

    @MainActor
    init(agent: AgentRecord, knownModels: [String]) {
        let inList = agent.modelID.isEmpty || knownModels.contains(agent.modelID)
        var phase: [ModelPhase: ModelReference] = [:]
        for entry in agent.phaseModels { if let p = ModelPhase(rawValue: entry.phase) { phase[p] = entry.model } }
        self.init(providerID: agent.providerID, source: inList ? .list : .custom, modelID: agent.modelID, phase: phase)
    }

    var trimmedModelID: String { modelID.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Same settings as the saved Agent (the source toggle alone is not a change).
    @MainActor
    func matches(_ agent: AgentRecord) -> Bool {
        providerID == agent.providerID && trimmedModelID == agent.modelID && phaseEntries == agent.phaseModels
    }

    /// The phase overrides as they'd be stored, in a stable order.
    /// A phase counts as configured only once both its provider and model are chosen (user 2026-09-16); a half-filled
    /// one is dropped, treated as not configured.
    static func isConfigured(_ model: ModelReference?) -> Bool {
        guard let model else { return false }
        return !model.providerID.isEmpty && !model.modelID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The phase overrides as they'd be stored, in a stable order — only the fully configured ones.
    var phaseEntries: [PhaseModel] {
        ModelPhase.allCases.compactMap { p in
            guard let model = phase[p], Self.isConfigured(model) else { return nil }
            return PhaseModel(phase: p.rawValue, model: ModelReference(providerID: model.providerID,
                                                                       modelID: model.modelID.trimmingCharacters(in: .whitespaces)))
        }
    }

    /// Why this can't be saved, or `nil`. A phase model follows the primary's rule: its provider must have a key.
    func problem(isConfigured: (String) -> Bool) -> String? {
        guard let providerID else { return "请选择服务商" }
        if !isConfigured(providerID) { return "服务商未配置，先在「设置 → 模型」填写 API Key" }
        if trimmedModelID.isEmpty { return "Model ID 不能为空" }
        // A half-filled phase is dropped (没选就当没配置); a fully-set one's provider must have a key.
        for p in ModelPhase.allCases {
            guard let model = phase[p], Self.isConfigured(model) else { continue }
            if !isConfigured(model.providerID) { return "\(p.title)的服务商未配置" }
        }
        return nil
    }
}

/// Whether an Agent can take work: active, authorized for the current project, primary model usable — all
/// three (design spec §8.7). One judgement for the list, the header and, later, the composer.
@MainActor
enum AgentReadiness {
    enum Status: Equatable {
        case active, modelUnavailable, stopped

        var label: String {
            switch self {
            case .active: "已激活"
            case .modelUnavailable: "模型不可用"
            case .stopped: "已停用"
            }
        }
    }

    static func isUsable(_ reference: ModelReference?, providers: ProviderStore) -> Bool {
        guard let reference, providers.entry(reference.providerID) != nil else { return false }
        return providers.hasKey(reference.providerID) && !reference.modelID.isEmpty
    }

    static func status(of agent: AgentRecord, providers: ProviderStore) -> Status {
        guard agent.isActive else { return .stopped }
        return isUsable(agent.primaryModel, providers: providers) ? .active : .modelUnavailable
    }

    /// The sentence that says what's missing and where to fix it; `nil` when the Agent can take work.
    static func blockReason(of agent: AgentRecord, currentProject: ProjectRecord?, providers: ProviderStore) -> String? {
        if !agent.isActive { return "Agent 已停用，去「概览 → 状态」重新激活" }
        guard let project = currentProject else { return "还没有打开项目" }
        if !agent.projectIDs.contains(project.id) { return "未授权当前项目，去「模型与权限 → 项目权限」勾选 \(project.name)" }
        if !isUsable(agent.primaryModel, providers: providers) {
            return "主模型不可用：服务商未配置或 Model ID 为空，去「模型与权限」处理"
        }
        return nil
    }
}
