import SwiftUI

/// The Agent detail column: header, tabs and the chosen tab (mockup `renderAgentDetailPane`), at most 860 wide.
/// With no Agent, the empty state (A2).
struct AgentDetailPane: View {
    let state: AppState
    let session: ProjectSession

    var body: some View {
        Group {
            if let agent = state.selectedAgent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        AgentHeader(state: state, session: session, agent: agent)
                        AgentTabs(state: state)
                        switch state.agentTab {
                        case .overview:
                            AgentStatStrip(state: state, session: session, agent: agent)
                            AgentOverviewTab(state: state, agent: agent)
                        case .model: AgentModelTab(state: state, session: session, agent: agent)
                        case .skills: AgentSkillsTab(state: state, agent: agent)
                        case .mcp: AgentMCPTab(state: state, agent: agent)
                        }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.vertical, 28)
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(VerificationHooks.agentScrollsToEnd ? .bottom : .top)
                .id("\(agent.id.uuidString)-\(state.agentTab.rawValue)")
            } else {
                AgentEmptyState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.agents")
    }
}

/// `.agent-detail-header`: 52pt avatar, name 17/700, status, subtitle; when the Agent can't take work, the
/// reason and where to fix it (spec §8.7).
private struct AgentHeader: View {
    let state: AppState
    let session: ProjectSession
    let agent: AgentRecord

    var body: some View {
        let status = AgentReadiness.status(of: agent, providers: state.providers)
        let reason = AgentReadiness.blockReason(of: agent, currentProject: session.current, providers: state.providers)
        HStack(spacing: 16) {
            AgentAvatar(image: state.agents.avatars[agent.id], initial: agent.role.initial, size: 52, isMuted: !agent.isActive)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text(agent.displayName)
                        .font(FormoraFont.ui(17, weight: 700))
                        .foregroundStyle(Palette.ink.color)
                        .lineLimit(1)
                        .accessibilityIdentifier("agent.header.name")
                    Text(status.label).font(FormoraFont.mono(10.5)).foregroundStyle(AgentStatusColor.of(status))
                        .accessibilityIdentifier("agent.header.status")
                }
                Text(agent.subtitle).font(FormoraFont.ui(12.5)).foregroundStyle(Palette.inkMuted.color).lineLimit(2)
                if let reason {
                    Text(reason)
                        .font(FormoraFont.ui(11))
                        .foregroundStyle(Palette.inkFaint.color)
                        .lineSpacing(2)
                        .padding(.top, 2)
                        .accessibilityIdentifier("agent.header.reason")
                }
            }
            Spacer(minLength: 0)
            // The only way into a direct chat (spec §9.2). Greyed while the Agent can't take work — the reason
            // is right beside it (D24).
            Button("发起对话") { state.startConversation(with: agent, project: session.current) }
                .buttonStyle(FormoraButtonStyle(kind: .primary))
                .disabled(reason != nil)
                .accessibilityIdentifier("agent.startConversation")
        }
        .padding(.bottom, 22)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
    }
}

/// `.agent-tabs`: 32pt pills; ←/→ move between them.
private struct AgentTabs: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppState.AgentTab.allCases) { tab in
                TabPill(title: tab.title, isOn: state.agentTab == tab, identifier: "agent.tab.\(tab.rawValue)") {
                    state.agentTab = tab
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .padding(.bottom, 22)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.tabs")
    }

    private func step(_ delta: Int) {
        let all = AppState.AgentTab.allCases
        guard let index = all.firstIndex(of: state.agentTab) else { return }
        state.agentTab = all[(index + delta + all.count) % all.count]
    }
}

private struct TabPill: View {
    let title: String
    let isOn: Bool
    let identifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FormoraFont.ui(11.5, weight: isOn ? 600 : 400))
                .foregroundStyle(isOn || isHovering ? Palette.ink.color : Palette.inkMuted.color)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(Capsule().fill(isOn ? Palette.surfaceRaised2.color : isHovering ? Palette.surfaceRaised.color : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// No Agent yet (user 2026-09-05, A2): a sketch of the list column whose only accent is the `+`, and one
/// sentence pointing at it. No second 「创建」 button — one action, one entry.
struct AgentEmptyState: View {
    var body: some View {
        VStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RoundedRectangle(cornerRadius: 3).fill(Palette.surfaceRaised2.color).frame(width: 46, height: 8)
                    Spacer(minLength: 0)
                    IconView(Icons.plus, size: 11)
                        .foregroundStyle(Palette.accent.color)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Palette.accentSoft.color))
                        .overlay(Circle().strokeBorder(Palette.accent.color.opacity(0.6), lineWidth: 1))
                }
                Capsule().fill(Palette.surfaceRaised.color).frame(height: 18)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Palette.lineStrong.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(height: 44)
            }
            .padding(14)
            .frame(width: 220)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
            .accessibilityHidden(true)
            Text("点击 Agent 列表右上角的 + 创建第一个 Agent")
                .font(FormoraFont.ui(13))
                .foregroundStyle(Palette.inkMuted.color)
                .accessibilityIdentifier("agents.empty.text")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents.empty")
    }
}
