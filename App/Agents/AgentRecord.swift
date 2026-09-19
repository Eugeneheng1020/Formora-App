import Foundation
import SwiftData

/// A provider + model pair. Stored by id so a provider that loses its key keeps the reference and shows as
/// unavailable instead of silently changing (design spec §8.7 rule 4).
struct ModelReference: Codable, Hashable, Sendable {
    var providerID: String
    var modelID: String
}

/// A phase of an Agent's work that can use a model of its own (user 2026-09-16; omp's model roles). Empty = the primary.
enum ModelPhase: String, CaseIterable, Codable, Sendable {
    /// Plan mode: 先出方案 (先看、先问、先出方案).
    case plan
    /// 旁审 / 复核: another model checks each step and the answer.
    case advisor
    /// A turn carrying images the primary can't see.
    case vision
    /// 省事: naming the task, compacting context, extracting memory — a cheaper model does.
    case chore

    var title: String {
        switch self {
        case .plan: "计划模型"
        case .advisor: "旁审模型"
        case .vision: "读图模型"
        case .chore: "省事模型"
        }
    }

    var note: String {
        switch self {
        case .plan: "计划模式下出方案用；点「按这个计划做」后实施还是用主模型。"
        case .advisor: "旁审和复核用；留空按「设置 → Bob」的模型，再没有就用主模型。"
        case .vision: "一轮里带了图、主模型看不了图时用。"
        case .chore: "起任务名、压缩上下文、整理记忆这些杂活用，挑个便宜的省钱。"
        }
    }
}

/// One phase's model (user 2026-09-16). Stored as an array like `fallbacks`, so adding it is a light migration.
struct PhaseModel: Codable, Hashable, Sendable {
    var phase: String
    var model: ModelReference
}

/// One Agent. Global — not tied to a project — and allowed into the projects listed in `projectIDs`.
@Model
final class AgentRecord {
    @Attribute(.unique) var id: UUID
    var roleID: String
    /// The part the user typed; the display name is 「角色（名称）」.
    var customName: String
    var subtitle: String
    var isActive: Bool
    var providerID: String?
    var modelID: String
    /// No longer used (user 2026-09-19: 舍弃备用模型): kept on disk so older stores open without a migration, never
    /// read by a run, emptied by the next save.
    var fallbacks: [ModelReference]
    /// Per-phase model overrides (user 2026-09-16). Default empty: a light migration.
    var phaseModels: [PhaseModel] = []
    var projectIDs: [UUID]
    /// Skill folder ids this Agent has switched on (spec §8.2). The default value makes adding the property a
    /// lightweight migration for stores written before 5b.
    var enabledSkills: [String] = []
    /// MCP servers this Agent may use and which of their tools (spec §8.4); saved explicitly.
    var mcpAccess: [MCPAccess] = []
    /// 权限模式 (7b, L5): the highest tool tier that runs without asking. Text, and a default, so adding it is a
    /// lightweight migration.
    var approvalModeRaw: String = ApprovalMode.write.rawValue
    /// 旁审 (10h; 7d's 写完自审 before): another model reads each step that changed something, and the run's answer.
    var reviewsOwnWork: Bool = false
    /// 允许操作电脑 (7j, B3): off by default; only the Developer ID build acts on it.
    var allowsComputer: Bool = false
    /// Whether `Agents/<id>.png` exists in the profile folder.
    var hasAvatar: Bool
    var createdAt: Date

    init(id: UUID = UUID(), roleID: String, customName: String, subtitle: String, isActive: Bool = true,
         providerID: String?, modelID: String, fallbacks: [ModelReference] = [], projectIDs: [UUID],
         hasAvatar: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.roleID = roleID
        self.customName = customName
        self.subtitle = subtitle
        self.isActive = isActive
        self.providerID = providerID
        self.modelID = modelID
        self.fallbacks = fallbacks
        self.projectIDs = projectIDs
        self.hasAvatar = hasAvatar
        self.createdAt = createdAt
    }

    var role: AgentRole { AgentRole.role(roleID) }
    var displayName: String { "\(role.name)（\(customName)）" }
    var primaryModel: ModelReference? { providerID.map { ModelReference(providerID: $0, modelID: modelID) } }
    /// The model for a phase, when one is set (user 2026-09-16).
    func model(for phase: ModelPhase) -> ModelReference? { phaseModels.first { $0.phase == phase.rawValue }?.model }
    var approvalMode: ApprovalMode { ApprovalMode(rawValue: approvalModeRaw) ?? .write }
}
