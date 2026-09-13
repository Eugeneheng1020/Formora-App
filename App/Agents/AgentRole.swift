/// The five fixed roles (design spec §7.1). 产品设计 is one Agent with the abilities of both a product manager
/// and a UI designer (user 2026-09-01). Templates appear only in the creation dialog.
struct AgentRole: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The default subtitle — the template's only description (spec §7.1).
    let summary: String

    /// At most this many Agents per role.
    static let limit = 10

    static let all: [AgentRole] = [
        AgentRole(id: "design", name: "产品设计", summary: "澄清需求并输出可执行的 PRD、交互稿与视觉方案。"),
        AgentRole(id: "dev", name: "研发", summary: "根据需求和设计完成代码实现、调试与本地验证。"),
        AgentRole(id: "qa", name: "测试", summary: "依据验收标准验证功能、异常路径与边界条件。"),
        AgentRole(id: "data", name: "数据分析", summary: "整理和分析真实数据，输出可核对的结论与建议。"),
        AgentRole(id: "ops", name: "运营", summary: "执行运营计划，跟踪效果并汇总真实用户反馈。"),
    ]

    static func role(_ id: String) -> AgentRole { all.first { $0.id == id } ?? all[0] }

    /// The avatar letter while no picture is set: the role's first character, whatever the Agent is called.
    var initial: String { String(name.prefix(1)) }
}
