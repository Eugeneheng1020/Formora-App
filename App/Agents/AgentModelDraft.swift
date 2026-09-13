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
    var fallbacks: [ModelReference]

    init(providerID: String? = nil, source: Source = .list, modelID: String = "", fallbacks: [ModelReference] = []) {
        self.providerID = providerID
        self.source = source
        self.modelID = modelID
        self.fallbacks = fallbacks
    }

    @MainActor
    init(agent: AgentRecord, knownModels: [String]) {
        let inList = agent.modelID.isEmpty || knownModels.contains(agent.modelID)
        self.init(providerID: agent.providerID, source: inList ? .list : .custom, modelID: agent.modelID,
                  fallbacks: agent.fallbacks)
    }

    var trimmedModelID: String { modelID.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Same settings as the saved Agent (the source toggle alone is not a change).
    @MainActor
    func matches(_ agent: AgentRecord) -> Bool {
        providerID == agent.providerID && trimmedModelID == agent.modelID && fallbacks == agent.fallbacks
    }

    /// Why this can't be saved, or `nil`. Fallbacks follow the same rule as the primary: their provider must
    /// have a key (spec §8.5 — the one v3 missed).
    func problem(isConfigured: (String) -> Bool) -> String? {
        guard let providerID else { return "请选择服务商" }
        if !isConfigured(providerID) { return "服务商未配置，先在「设置 → 模型」填写 API Key" }
        if trimmedModelID.isEmpty { return "Model ID 不能为空" }
        if fallbacks.count > 3 { return "备用模型不能超过 3 个" }
        for (index, fallback) in fallbacks.enumerated() {
            if fallback.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "第 \(index + 1) 个备用模型还没有选择模型" }
            if !isConfigured(fallback.providerID) { return "第 \(index + 1) 个备用模型的服务商未配置" }
        }
        let primary = ModelReference(providerID: providerID, modelID: trimmedModelID)
        if fallbacks.contains(primary) { return "备用模型不能与主模型重复" }
        if Set(fallbacks).count != fallbacks.count { return "备用模型不能重复" }
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
