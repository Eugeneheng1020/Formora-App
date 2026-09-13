import Foundation
import SwiftData

/// A provider + model pair. Stored by id so a provider that loses its key keeps the reference and shows as
/// unavailable instead of silently changing (design spec §8.7 rule 4).
struct ModelReference: Codable, Hashable, Sendable {
    var providerID: String
    var modelID: String
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
    var fallbacks: [ModelReference]
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
    var reviewsOwnWork: Bool = true
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
    var approvalMode: ApprovalMode { ApprovalMode(rawValue: approvalModeRaw) ?? .write }
}
