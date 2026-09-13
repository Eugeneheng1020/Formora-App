import Foundation

/// The cold start (user 2026-09-09, the old plan's 待办 11): project → model → Agent → ready. Every step after the
/// project can be skipped, one already done is skipped by itself, and the project opens only at the end — quitting half
/// way never lands in a window where nothing can run.
struct LaunchSetup: Equatable {
    enum Step: Int, CaseIterable, Sendable {
        case project = 1, model, agent, ready
    }

    /// No provider has a key or a sign-in yet.
    var needsModel: Bool
    /// No Agent yet.
    var needsAgent: Bool

    static let stepCount = Step.allCases.count

    @MainActor
    static func current(providers: ProviderStore, agents: AgentStore) -> LaunchSetup {
        LaunchSetup(needsModel: !providers.entries.contains { providers.hasKey($0.id) }, needsAgent: agents.agents.isEmpty)
    }

    /// Something to set up: the steps show with their count, and the last one says it's ready.
    var isGuided: Bool { needsModel || needsAgent }

    /// The step after `step`; `nil`: straight into the main window.
    func next(after step: Step) -> Step? {
        switch step {
        case .project: needsModel ? .model : needsAgent ? .agent : nil
        case .model: needsAgent ? .agent : .ready
        case .agent: .ready
        case .ready: nil
        }
    }

    /// The name the first Agent's field starts with: the user can change it.
    static func suggestedName(for roleID: String) -> String {
        ["design": "小设", "dev": "小研", "qa": "小测", "data": "小数", "ops": "小运"][roleID] ?? "小助手"
    }
}
