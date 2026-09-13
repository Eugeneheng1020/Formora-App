import SwiftUI

/// The Agent list column (mockup `renderAgentList`): title + `+`, search, `.conv-item` rows laid out like the
/// 消息 list (user 2026-09-05). With no Agent at all it stays quiet — the detail column explains (A2).
struct AgentListColumn: View {
    let state: AppState

    @State private var search = ""

    private var agents: [AgentRecord] { state.agents.agents }

    /// Name and role, matched like the file tree's search (case and full width folded).
    private var visible: [AgentRecord] {
        let query = FileSearch.normalize(search)
        guard !query.isEmpty else { return agents }
        return agents.filter { FileSearch.normalize("\($0.displayName) \($0.role.name)").contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text("Agent")
                        .font(FormoraFont.ui(19, weight: 700))
                        .tracking(-0.19)
                        .foregroundStyle(Palette.ink.color)
                        .accessibilityIdentifier("list.title")
                    Spacer(minLength: 0)
                    ListAddButton(label: "创建 Agent", identifier: "agents.add") { state.isCreatingAgent = true }
                }
                .frame(height: 26)
                .padding(.bottom, 14)
                if agents.isEmpty {
                    Color.clear.frame(height: 10) // the empty `.filter-tabs` row
                } else {
                    SearchField(placeholder: "搜索 Agent", text: $search, identifier: "agents.search")
                        .padding(.bottom, 22)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 18)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(visible) { agent in
                        AgentRow(state: state, agent: agent)
                    }
                    if !agents.isEmpty, visible.isEmpty {
                        Text("没有匹配的 Agent")
                            .font(FormoraFont.ui(12))
                            .foregroundStyle(Palette.inkFaint.color)
                            .padding(.vertical, 34)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("agents.noMatch")
                    }
                }
                .padding(.top, 2)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agents.list")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface.color)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line.color).frame(width: 1) }
    }

    private func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == state.selectedAgent?.id } ?? (delta > 0 ? -1 : list.count)
        state.requestAgent(list[min(max(index + delta, 0), list.count - 1)].id)
    }
}

private struct AgentRow: View {
    let state: AppState
    let agent: AgentRecord

    @State private var isHovering = false

    private var isSelected: Bool { state.selectedAgent?.id == agent.id }

    var body: some View {
        let status = AgentReadiness.status(of: agent, providers: state.providers)
        Button { state.requestAgent(agent.id) } label: {
            HStack(spacing: 10) {
                AgentAvatar(image: state.agents.avatars[agent.id], initial: agent.role.initial, size: 40, isMuted: !agent.isActive)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(agent.displayName)
                            .font(FormoraFont.ui(13.5, weight: 600))
                            .foregroundStyle(Palette.ink.color)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(status.label).font(FormoraFont.mono(10.5)).foregroundStyle(AgentStatusColor.of(status))
                        if state.hasUnsavedDraft(agent.id) {
                            Circle().fill(Palette.accent.color).frame(width: 6, height: 6)
                                .help("有未保存的模型修改")
                                .accessibilityLabel("有未保存修改")
                        }
                    }
                    Text(agent.subtitle)
                        .font(FormoraFont.ui(12.5))
                        .foregroundStyle(Palette.inkMuted.color)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Palette.surfaceRaised2.color : isHovering ? Palette.surfaceRaised.color : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Palette.lineStrong.color : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // Icon + text, like the 消息 list's menu (user 2026-09-08).
        .contextMenu {
            Button { AgentActions.setActive(agent, !agent.isActive, state: state) } label: {
                Label { Text(agent.isActive ? "停用" : "激活") } icon: { Image(nsImage: Icons.power.templateImage()) }
            }
            Button(role: .destructive) { state.agentToDelete = agent.id } label: {
                Label { Text("删除") } icon: { Image(nsImage: Icons.trash.templateImage()) }
            }
        }
        .accessibilityLabel("\(agent.displayName)，\(status.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("agents.row.\(agent.customName)")
    }
}

/// `.agent-status-tag`: online green, warn alert, offline faint.
enum AgentStatusColor {
    static func of(_ status: AgentReadiness.Status) -> Color {
        switch status {
        case .active: Palette.success.color
        case .modelUnavailable: Palette.alert.color
        case .stopped: Palette.inkFaint.color
        }
    }
}

/// Actions shared by the list's context menu and the detail page.
@MainActor
enum AgentActions {
    static func setActive(_ agent: AgentRecord, _ active: Bool, state: AppState) {
        do {
            try state.agents.setActive(agent, active)
            state.toasts.show(active ? "Agent 已激活" : "Agent 已停用",
                              note: active ? "\(agent.displayName) 可以接收新任务" : "历史对话与任务记录已保留")
        } catch {
            state.toasts.show("状态没有更改", note: error.localizedDescription, isError: true)
        }
    }

    static func delete(_ id: UUID, state: AppState) {
        guard let agent = state.agents.agent(id) else { return }
        let name = agent.displayName
        do {
            try state.agents.delete(agent)
            for conversation in state.conversations.conversations where conversation.agentID == id {
                state.chat.discard(conversation.id)
            }
            state.conversations.agentDeleted(id)
            // Its memories go with it (7f, F4).
            state.chat.memory?.forget(agent: id)
            state.modelDrafts[id] = nil
            if state.selectedAgentID == id { state.selectedAgentID = state.agents.agents.first?.id }
            state.toasts.show("已删除「\(name)」")
        } catch {
            state.toasts.show("没有删除", note: error.localizedDescription, isError: true)
        }
    }
}
