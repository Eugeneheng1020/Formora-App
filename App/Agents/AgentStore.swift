import AppKit
import Foundation
import Observation
import SwiftData

enum AgentProblem: Error, Equatable {
    case nameEmpty, nameTooLong, nameTaken
    case roleFull(String)
    case noProject
    case model(String)

    /// The mockup's wording (`validateCreateIdentity`).
    var message: String {
        switch self {
        case .nameEmpty: "名称为必填项"
        case .nameTooLong: "去除首尾空格后不能超过 20 个字符"
        case .nameTaken: "名称已被其他 Agent 使用（不区分英文大小写）"
        case .roleFull(let role): "\(role)已达上限 \(AgentRole.limit)/\(AgentRole.limit)"
        case .noProject: "至少授权 1 个项目"
        case .model(let message): message
        }
    }
}

/// What the creation dialog hands over.
struct NewAgent: Sendable {
    var roleID: String
    var name: String
    var subtitle: String
    /// Prepared PNG (`AvatarImage.prepare`), or `nil` for the role letter.
    var avatarPNG: Data?
    var providerID: String?
    var modelID: String
    var projectIDs: [UUID]
}

/// Agents in SwiftData (same container as projects) and their avatar files. Main actor only.
@MainActor
@Observable
final class AgentStore {
    nonisolated static let maxNameLength = 20
    nonisolated static let maxSubtitleLength = 50

    /// Newest first (a new Agent is inserted at the top, like the mockup's `unshift`).
    private(set) var agents: [AgentRecord] = []
    private(set) var avatars: [UUID: NSImage] = [:]

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let avatarFolder: URL?

    /// `avatarFolder == nil` keeps avatars in memory only (tests).
    init(container: ModelContainer, avatarFolder: URL?) {
        self.container = container
        self.context = container.mainContext
        self.avatarFolder = avatarFolder
        reload()
    }

    func reload() {
        let descriptor = FetchDescriptor<AgentRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        agents = (try? context.fetch(descriptor)) ?? []
        for agent in agents where agent.hasAvatar && avatars[agent.id] == nil {
            if let url = avatarURL(agent.id), let image = NSImage(contentsOf: url) { avatars[agent.id] = image }
        }
    }

    func agent(_ id: UUID?) -> AgentRecord? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    func count(ofRole roleID: String) -> Int { agents.filter { $0.roleID == roleID }.count }

    // MARK: Rules (design spec §7.1)

    func nameProblem(_ raw: String, excluding id: UUID? = nil) -> AgentProblem? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .nameEmpty }
        if name.unicodeScalars.count > Self.maxNameLength { return .nameTooLong }
        let normalized = FileSearch.normalize(name)
        if agents.contains(where: { $0.id != id && FileSearch.normalize($0.customName) == normalized }) { return .nameTaken }
        return nil
    }

    /// Typing past 50 code points has no effect: returns `nil` for input that must be refused.
    nonisolated static func acceptSubtitle(_ raw: String) -> String? {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > maxSubtitleLength ? nil : raw
    }

    /// Empty falls back to the role's default.
    nonisolated static func finalSubtitle(_ raw: String, role: AgentRole) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? role.summary : String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maxSubtitleLength)))
    }

    // MARK: Changes

    @discardableResult
    func create(_ new: NewAgent) throws -> AgentRecord {
        let role = AgentRole.role(new.roleID)
        if count(ofRole: role.id) >= AgentRole.limit { throw AgentProblem.roleFull(role.name) }
        if let problem = nameProblem(new.name) { throw problem }
        guard !new.projectIDs.isEmpty else { throw AgentProblem.noProject }
        let record = AgentRecord(roleID: role.id, customName: new.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 subtitle: Self.finalSubtitle(new.subtitle, role: role), providerID: new.providerID,
                                 modelID: new.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
                                 projectIDs: new.projectIDs)
        context.insert(record)
        try context.save()
        if let png = new.avatarPNG { try? storeAvatar(png, for: record) }
        reload()
        return record
    }

    func rename(_ agent: AgentRecord, to raw: String) throws {
        if let problem = nameProblem(raw, excluding: agent.id) { throw problem }
        agent.customName = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        try context.save()
    }

    func setSubtitle(_ agent: AgentRecord, to raw: String) throws {
        agent.subtitle = Self.finalSubtitle(raw, role: agent.role)
        try context.save()
    }

    func setActive(_ agent: AgentRecord, _ active: Bool) throws {
        agent.isActive = active
        try context.save()
    }

    func setApprovalMode(_ agent: AgentRecord, _ mode: ApprovalMode) throws {
        agent.approvalModeRaw = mode.rawValue
        try context.save()
    }

    func setReviewsOwnWork(_ agent: AgentRecord, _ isOn: Bool) throws {
        agent.reviewsOwnWork = isOn
        try context.save()
    }

    func setAllowsComputer(_ agent: AgentRecord, _ isOn: Bool) throws {
        agent.allowsComputer = isOn
        try context.save()
    }

    /// At least one project must stay (spec §7.3).
    func setProjects(_ agent: AgentRecord, to ids: [UUID]) throws {
        guard !ids.isEmpty else { throw AgentProblem.noProject }
        agent.projectIDs = ids
        try context.save()
    }

    func saveModel(_ agent: AgentRecord, _ draft: AgentModelDraft, isConfigured: (String) -> Bool) throws {
        if let problem = draft.problem(isConfigured: isConfigured) { throw AgentProblem.model(problem) }
        agent.providerID = draft.providerID
        agent.modelID = draft.trimmedModelID
        agent.fallbacks = draft.fallbacks
        agent.phaseModels = draft.phaseEntries
        try context.save()
    }

    func setAvatar(_ agent: AgentRecord, from url: URL) throws {
        try storeAvatar(AvatarImage.prepare(from: url), for: agent)
    }

    func delete(_ agent: AgentRecord) throws {
        if let url = avatarURL(agent.id) { try? FileManager.default.removeItem(at: url) }
        avatars[agent.id] = nil
        context.delete(agent)
        try context.save()
        reload()
    }

    /// Switches a Skill on or off for one Agent (auto-saved, spec §8.1).
    func setSkill(_ agent: AgentRecord, _ skillID: String, enabled: Bool) throws {
        if enabled {
            if !agent.enabledSkills.contains(skillID) { agent.enabledSkills.append(skillID) }
        } else {
            agent.enabledSkills.removeAll { $0 == skillID }
        }
        try context.save()
    }

    /// The MCP tab's explicit save.
    func saveMCP(_ agent: AgentRecord, _ access: [MCPAccess]) throws {
        agent.mcpAccess = access
        try context.save()
    }

    /// Agents that enable this MCP server — deleting waits until it's 0.
    func usage(ofMCP id: String) -> Int { agents.filter { $0.mcpAccess.contains { $0.serverID == id } }.count }

    /// Agents that enable this Skill — uninstalling waits until it's 0.
    func usage(ofSkill id: String) -> Int { agents.filter { $0.enabledSkills.contains(id) }.count }

    /// Agents whose primary or fallback model uses this provider (spec §7.4, §8.7 rule 2).
    func usage(ofProvider id: String) -> Int {
        agents.filter { $0.providerID == id || $0.fallbacks.contains { $0.providerID == id }
            || $0.phaseModels.contains { $0.model.providerID == id } }.count
    }

    // MARK: Avatars

    private func avatarURL(_ id: UUID) -> URL? {
        avatarFolder?.appendingPathComponent("\(id.uuidString).png")
    }

    private func storeAvatar(_ png: Data, for agent: AgentRecord) throws {
        if let folder = avatarFolder, let url = avatarURL(agent.id) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        }
        avatars[agent.id] = NSImage(data: png)
        agent.hasAvatar = true
        try context.save()
    }
}
