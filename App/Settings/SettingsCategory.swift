/// The categories 设置 lists. Only categories that work are here (user 2026-09-11): Skills and MCP arrive
/// with Agents, 归档 with Messages, 通知 with real replies (6b), and Bob with the agent core (7h) — a page of his own, last.
enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    /// 模型 → Skills → MCP: the same order as the Agent detail tabs (spec §5); Hooks after them (7b′, D39);
    /// 通知 → 归档 as in the mockup, 电脑操作 between them (7j, B2, old D40).
    case account, models, skills, mcp, hooks, notifications, computer, archive, bob

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: "账户"
        case .models: "模型"
        case .skills: "Skills"
        case .mcp: "MCP"
        case .hooks: "Hooks"
        case .notifications: "通知"
        case .computer: "电脑操作"
        case .archive: "归档"
        case .bob: "Bob"
        }
    }

    /// `.pane-eyebrow`: mono, uppercase.
    var eyebrow: String { rawValue.uppercased() }

    var icon: SVGIcon {
        switch self {
        case .account: Icons.person
        case .models: Icons.chip
        case .skills: Icons.sparkle
        case .mcp: Icons.plug
        case .hooks: Icons.hook
        case .notifications: Icons.bell
        case .computer: Icons.display
        case .archive: Icons.archive
        case .bob: Icons.robot
        }
    }
}
