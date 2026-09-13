/// Rail sections in the mockup's real top-to-bottom order (design spec §3).
enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case messages, agents, board, files, settings

    var id: String { rawValue }

    static let mainNavigation: [AppSection] = [.messages, .agents, .board, .files]

    var title: String {
        switch self {
        case .messages: "消息"
        case .agents: "Agent"
        case .board: "看板"
        case .files: "文件"
        case .settings: "设置"
        }
    }

    var icon: SVGIcon {
        switch self {
        case .messages: Icons.messages
        case .agents: Icons.agents
        case .board: Icons.board
        case .files: Icons.files
        case .settings: Icons.settings
        }
    }
}
