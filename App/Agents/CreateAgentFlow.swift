import Foundation

/// The creation dialog's state and rules (design spec §7.2), kept out of the view so they can be tested.
struct CreateAgentFlow: Equatable {
    enum Step: Int, Equatable {
        case identity = 1, model, projects
    }

    enum Connection: Equatable {
        case idle, testing
        /// Passed for exactly this provider + model.
        case success(fingerprint: String, note: String?)
        case failed(String)
        case timedOut
    }

    var step: Step = .identity
    var roleID: String
    var name = ""
    var subtitle: String
    var avatarPNG: Data?
    var avatarProblem: String?
    var nameProblem: AgentProblem?
    var model = AgentModelDraft()
    var connection: Connection = .idle
    var projectIDs: Set<UUID>
    var projectProblem = false
    var isCreating = false

    /// First role with room, its default subtitle, the first provider with a key, the current project.
    @MainActor
    init(agents: AgentStore, providers: ProviderStore, currentProject: UUID?) {
        let role = AgentRole.all.first { agents.count(ofRole: $0.id) < AgentRole.limit } ?? AgentRole.all[0]
        roleID = role.id
        subtitle = role.summary
        model.providerID = providers.entries.first { providers.hasKey($0.id) }?.id
        projectIDs = currentProject.map { [$0] } ?? []
    }

    var fingerprint: String { "\(model.providerID ?? "")/\(model.trimmedModelID)" }

    /// Picking another role brings that role's default subtitle (spec §7.1).
    mutating func chooseRole(_ role: AgentRole) {
        if role.id != roleID {
            roleID = role.id
            subtitle = role.summary
        }
        nameProblem = nil
    }

    /// Any change of provider or model makes an earlier test result stale.
    mutating func modelChanged() {
        connection = .idle
    }

    /// Provider configured and a Model ID; then untested or tested OK *for this choice* may continue — testing,
    /// failed and timed out may not (spec §7.2).
    func canLeaveModelStep(isConfigured: (String) -> Bool) -> Bool {
        guard let provider = model.providerID, isConfigured(provider), !model.trimmedModelID.isEmpty else { return false }
        switch connection {
        case .idle: return true
        case .success(let passed, _): return passed == fingerprint
        case .testing, .failed, .timedOut: return false
        }
    }
}
