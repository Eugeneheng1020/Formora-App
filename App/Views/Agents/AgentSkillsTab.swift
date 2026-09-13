import SwiftUI

/// The Agent's Skills tab (spec §8.2): every installed Skill with this Agent's switch — last in the row
/// (spec §4.1). No permission settings (todo #1): an enabled Skill works with the Agent's own permissions.
struct AgentSkillsTab: View {
    let state: AppState
    let agent: AgentRecord

    var body: some View {
        DetailBlock(title: "Skills", note: "全局安装，当前 Agent 独立启用。启用后，Agent 会在需要时读取它的全文。", isLast: true) {
            Button("导入文件夹") { SkillImport.run(state: state, enableFor: agent) }
                .buttonStyle(FormoraButtonStyle(kind: .primary))
                .accessibilityIdentifier("agent.skills.import")
        } content: {
            if state.skills.skills.isEmpty {
                Text("还没有安装 Skill。去「设置 → Skills」导入，或在这里导入一个文件夹。")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkFaint.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                VStack(spacing: 0) {
                    ForEach(state.skills.skills) { skill in row(skill) }
                }
                .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agent.skills.list")
            }
        }
    }

    private func row(_ skill: Skill) -> some View {
        HStack(spacing: 11) {
            CapabilityMark(text: skill.mark)
            SkillSummary(skill: skill)
            FormoraSwitch(isOn: Binding(get: { agent.enabledSkills.contains(skill.id) },
                                        set: { toggle(skill, $0) }),
                          label: "为 \(agent.displayName) 启用 \(skill.name)", identifier: "agent.skill.\(skill.id)")
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
    }

    private func toggle(_ skill: Skill, _ enabled: Bool) {
        do {
            try state.agents.setSkill(agent, skill.id, enabled: enabled)
            state.toasts.show("已保存", note: "\(skill.name) 已\(enabled ? "启用" : "停用")", seconds: 2)
        } catch {
            state.toasts.show("没有更改", note: error.localizedDescription, isError: true)
        }
    }
}

/// `.agent-stat-strip`: counts that open the matching tab — each number equals what that tab shows
/// (design checklist 21).
struct AgentStatStrip: View {
    let state: AppState
    let session: ProjectSession
    let agent: AgentRecord

    var body: some View {
        let projects = session.projects.filter { agent.projectIDs.contains($0.id) }.count
        let installed = Set(state.skills.skills.map(\.id))
        let skills = agent.enabledSkills.filter(installed.contains).count
        let servers = Set(state.mcp.servers.map(\.id))
        let mcp = agent.mcpAccess.filter { servers.contains($0.serverID) }.count
        HStack(spacing: 0) {
            cell("\(projects)/\(session.projects.count)", "授权项目", tab: .model, first: true)
            Rectangle().fill(Palette.line.color).frame(width: 1)
            cell("\(skills)/\(installed.count)", "已启用 Skills", tab: .skills, first: false)
            Rectangle().fill(Palette.line.color).frame(width: 1)
            cell("\(mcp)/\(servers.count)", "已启用 MCP", tab: .mcp, first: false)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .padding(.bottom, 26)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.stats")
    }

    private func cell(_ value: String, _ label: String, tab: AppState.AgentTab, first: Bool) -> some View {
        StatCell(value: value, label: label, leadingPadding: first ? 0 : 14) { state.agentTab = tab }
            .accessibilityIdentifier("agent.stat.\(tab.rawValue)")
    }
}

private struct StatCell: View {
    let value: String
    let label: String
    let leadingPadding: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(FormoraFont.mono(16, weight: 600))
                    .foregroundStyle(isHovering ? Palette.accent.color : Palette.ink.color)
                Text(label).font(FormoraFont.ui(10.5)).foregroundStyle(Palette.inkFaint.color)
            }
            .padding(.vertical, 13)
            .padding(.leading, leadingPadding)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
